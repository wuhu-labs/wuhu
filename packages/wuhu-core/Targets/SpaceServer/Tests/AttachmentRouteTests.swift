import Dependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import Synchronization
import Testing

private let anthropicModelsJSON = """
{
  "anthropic": {
    "dialect": "anthropic",
    "baseURL": "https://api.anthropic.com/v1",
    "models": {
      "claude-test": {
        "maxInput": 200000,
        "maxOutput": 1000,
        "efforts": ["low", "high"],
        "defaultEffort": "low"
      }
    }
  }
}
"""

private let postedAt = Date(timeIntervalSince1970: 1_790_313_889)

private func withFixedClock<R>(_ body: () async throws -> R) async throws -> R {
  try await withSessionDeps {
    try await withDependencies {
      $0.date = .constant(postedAt)
    } operation: {
      try await body()
    }
  }
}

// A multipart body whose file bytes are generated as it is read, so a test
// can send the size limits without holding them.
private struct Pieces: AsyncSequence, Sendable {
  let pieces: [(bytes: Data, times: Int)]

  struct AsyncIterator: AsyncIteratorProtocol {
    var pieces: ArraySlice<(bytes: Data, times: Int)>
    var sent = 0

    mutating func next() async -> Data? {
      while let piece = pieces.first {
        if sent < piece.times {
          sent += 1
          return piece.bytes
        }
        pieces = pieces.dropFirst()
        sent = 0
      }
      return nil
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(pieces: pieces[...])
  }
}

private let boundary = "wuhu-test-boundary"

private func fileHeader(_ name: String) -> Data {
  Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
}

private func messagePart(_ fields: JSONValue) -> Data {
  Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"message\"\r\nContent-Type: application/json\r\n\r\n\(fields.jsonString())\r\n".utf8)
}

private let mebibyte = Data(repeating: 0x41, count: 1 << 20)

private extension SessionHarness {
  func multipart(_ id: SessionID, _ files: [(String, Data)], paths: [String] = []) async throws -> Response {
    var form = MultipartForm(boundary: boundary)
    var entries: [(String, JSONValue)] = [("message", "look"), ("session", .string(id.rawValue))]
    if !paths.isEmpty {
      entries.append(("attachments", .array(paths.map(JSONValue.string))))
    }
    let fields = JSONValue.object(.init(uniqueKeysWithValues: entries))
    form.appendField("message", fields.jsonString(), contentType: "application/json")
    for (name, bytes) in files {
      form.appendFile(name: "file", filename: name, contentType: "application/octet-stream", bytes: bytes)
    }
    return try await send(form.finish(), contentType: form.contentType)
  }

  // Sizes in bytes; each file is filled with whole mebibytes plus a tail.
  func streamed(_ id: SessionID, sizes: [Int]) async throws -> Response {
    var pieces: [(bytes: Data, times: Int)] = [(messagePart(.object(["message": "big", "session": .string(id.rawValue)])), 1)]
    for (index, size) in sizes.enumerated() {
      pieces.append((fileHeader("part\(index).bin"), 1))
      pieces.append((mebibyte, size >> 20))
      pieces.append((Data(repeating: 0x41, count: size & ((1 << 20) - 1)), 1))
      pieces.append((Data("\r\n".utf8), 1))
    }
    pieces.append((Data("--\(boundary)--\r\n".utf8), 1))
    let contentType = "multipart/form-data; boundary=\(boundary)"
    return try await send(.stream(contentType: contentType, Pieces(pieces: pieces.filter { !$0.bytes.isEmpty })), contentType: contentType)
  }

  func send(_ body: Body, contentType: String) async throws -> Response {
    var request = Request(url: URL(string: "http://space/v1/conversation/message")!, method: .post)
    request.body = body
    request.headers[.contentType] = contentType
    return try await api(request)
  }

  func postToBox(_ id: SessionID, paths: [String]) async throws -> Response {
    try await post(
      "/v1/conversation/message",
      .object(["message": "look", "session": .string(id.rawValue), "attachments": .array(paths.map(JSONValue.string))]),
    )
  }

  func attachments(of post: ConversationPostOutput) async throws -> [AttachmentPayload] {
    let response = try await get("/v1/conversation/\(post.conversationId)/messages", query: ["after": "0"])
    let read = try JSONValueDecoder().decode(
      ConversationReadOutput.self, from: try #require(JSONValue.parse(try await response.text())),
    )
    return try #require(read.messages.first { $0.messageId == post.messageId }?.attachments)
  }

  func accepted(_ response: Response) async throws -> (ConversationPostOutput, [String]) {
    let text = try await response.text()
    #expect(response.status == .ok, "\(text)")
    let output = try JSONValueDecoder().decode(ConversationPostOutput.self, from: try #require(JSONValue.parse(text)))
    return (output, try await self.attachments(of: output).map(\.path))
  }

  func stored(_ post: ConversationPostOutput) async throws -> [SessionDomain.Attachment] {
    let messages = try await store.messages(conversation: ConversationID(post.conversationId))
    return try #require(messages.first { $0.id.rawValue == post.messageId }).content.attachments
  }
}

private func refusal(_ response: Response) async throws -> (Status, String) {
  let text = try await response.text()
  let value = try #require(JSONValue.parse(text))
  return (response.status, value.object?["code"]?.stringValue ?? text)
}

@Suite struct AttachmentRouteTests {
  private let pixels = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  // The assembled runtime is the only path that resolves attachment bytes; the
  // scripted-inference harness bypasses it entirely, so this asserts the
  // provider request body the real closure produces.
  @Test func theAssembledRuntimeSendsAttachmentBytesToTheProvider() async throws {
    let captured = Mutex<[String]>([])
    try await withSessionDeps {
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.data() ?? Data()
          captured.withLock { $0.append(String(decoding: body, as: UTF8.self)) }
          return Response(
            status: .badRequest,
            body: .bytes(Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"stub"}}"#.utf8), contentType: "application/json"),
          )
        }
      } operation: {
        let harness = try await SessionHarness(assembledModels: anthropicModelsJSON)
        try await harness.running {
          let id = try await harness.createSession(provider: "anthropic", model: "claude-test")
          _ = try await harness.accepted(harness.multipart(id, [("shot.png", pixels), ("clip.mp4", Data("not really".utf8))]))
          try await until("the kernel reaches the provider") { !captured.withLock { $0 }.isEmpty }
          let body = try #require(captured.withLock { $0 }.first)
          #expect(body.contains(#""type":"image""#))
          #expect(body.contains(#""media_type":"image/png""#))
          #expect(body.contains(pixels.base64EncodedString()))
          #expect(body.contains("clip.mp4 (video/mp4, 10 bytes)"))
          #expect(!body.contains(Data("not really".utf8).base64EncodedString()))
        }
      }
    }
  }

  @Test func uploadedBytesLandInTheMessagesOwnFolderUnderItsOriginalName() async throws {
    try await withFixedClock {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let (post, attachments) = try await harness.accepted(harness.multipart(id, [("shot.png", pixels)]))
      let copy = "/_/conversations/\(post.conversationId)/attachments/2026/09/25/052449Z/shot.png"
      #expect(attachments == [copy])
      #expect(try await harness.space.fs(.shared).read(copy).1 == pixels)
    }
  }

  @Test func aStoredImageRecordsItsSize() async throws {
    try await withFixedClock {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let (post, attachments) = try await harness.accepted(harness.multipart(id, [("shot.png", pixels)]))
      #expect(try await harness.stored(post) == [.image(path: attachments[0], mimeType: "image/png", size: pixels.count)])
    }
  }

  @Test func anyFileTypeIsStoredWithItsTypeAndSizeAndOnlyMatchingImagesAreImages() async throws {
    try await withFixedClock {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let pdf = Data("%PDF-1.7 not much of one".utf8)
      let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
      let big = pixels + Data(repeating: 0, count: ImageMedia.maxBytes)
      let (post, _) = try await harness.accepted(harness.multipart(id, [
        ("report.pdf", pdf), ("liar.png", jpeg), ("big.png", big), ("README", Data("hi".utf8)),
      ]))
      let folder = "/_/conversations/\(post.conversationId)/attachments/2026/09/25/052449Z"
      let expected: [SessionDomain.Attachment] = [
        .file(path: folder + "/report.pdf", mimeType: "application/pdf", size: pdf.count),
        .file(path: folder + "/liar.png", mimeType: "image/png", size: jpeg.count),
        .image(path: folder + "/big.png", mimeType: "image/png", size: big.count),
        .file(path: folder + "/README", mimeType: "application/octet-stream", size: 2),
      ]
      let stored = try await harness.stored(post)
      #expect(stored == expected)
      #expect(try await harness.attachments(of: post) == [
        AttachmentPayload(kind: .file, path: folder + "/report.pdf", mimeType: "application/pdf", size: pdf.count),
        AttachmentPayload(kind: .file, path: folder + "/liar.png", mimeType: "image/png", size: jpeg.count),
        AttachmentPayload(kind: .image, path: folder + "/big.png", mimeType: "image/png", size: big.count),
        AttachmentPayload(kind: .file, path: folder + "/README", mimeType: "application/octet-stream", size: 2),
      ])
    }
  }

  @Test func aPathAttachmentIsCopiedAndLaterEditsToTheOriginalDoNotReachIt() async throws {
    try await withFixedClock {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      _ = try await harness.space.fs(.shared).write("/shots/shot.png", pixels, ifMatch: nil)
      _ = try await harness.space.fs(.shared).write("/notes/plan.md", Data("# plan".utf8), ifMatch: nil)

      let (post, attachments) = try await harness.accepted(harness.postToBox(id, paths: ["/shots/shot.png", "/notes/plan.md"]))
      let folder = "/_/conversations/\(post.conversationId)/attachments/2026/09/25/052449Z"
      #expect(attachments == ["\(folder)/shot.png", "\(folder)/plan.md"])

      _ = try await harness.space.fs(.shared).write("/shots/shot.png", Data("rewritten".utf8), ifMatch: nil)
      try await harness.space.fs(.shared).delete("/notes/plan.md", ifMatch: nil)
      #expect(try await harness.space.fs(.shared).read("\(folder)/shot.png").1 == pixels)
      #expect(try await harness.space.fs(.shared).read("\(folder)/plan.md").1 == Data("# plan".utf8))
    }
  }

  @Test func aClashingNameTakesTheNextFreeOrdinalWithinAPostAndAcrossPostsInOneSecond() async throws {
    try await withFixedClock {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      _ = try await harness.space.fs(.shared).write("/elsewhere/shot.png", pixels, ifMatch: nil)

      let (post, first) = try await harness.accepted(harness.multipart(
        id, [("shot.png", pixels), ("shot.png", pixels)], paths: ["/elsewhere/shot.png"],
      ))
      let folder = "/_/conversations/\(post.conversationId)/attachments/2026/09/25/052449Z"
      #expect(first == ["\(folder)/shot.png", "\(folder)/shot-2.png", "\(folder)/shot-3.png"])

      let (_, second) = try await harness.accepted(harness.multipart(id, [("shot.png", pixels)]))
      #expect(second == ["\(folder)/shot-4.png"])
    }
  }

  @Test func anUploadedNameIsReducedToOneValidPathComponent() async throws {
    try await withFixedClock {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let (post, attachments) = try await harness.accepted(harness.multipart(id, [("../dir/a#b?.png", pixels), ("..", pixels)]))
      let folder = "/_/conversations/\(post.conversationId)/attachments/2026/09/25/052449Z"
      #expect(attachments == ["\(folder)/a_b_.png", "\(folder)/attachment"])
    }
  }

  @Test func theAttachmentFolderIsWriteOnceForTheFileVerbs() async throws {
    try await withFixedClock {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      _ = try await harness.space.fs(.shared).write("/loose.png", pixels, ifMatch: nil)
      let (post, attachments) = try await harness.accepted(harness.multipart(id, [("shot.png", pixels)]))
      let copy = try #require(attachments.first)
      let folder = "/_/conversations/\(post.conversationId)/attachments"

      let refused: [(String, JSONValue)] = [
        ("write", .object(["path": .string(copy), "content": "x"])),
        ("write", .object(["path": .string("\(folder)/new.png"), "content": "x"])),
        ("rm", .object(["path": .string(copy)])),
        ("rm", .object(["path": .string(folder)])),
        ("mv", .object(["from": .string(copy), "to": "/stolen.png"])),
        ("mv", .object(["from": "/loose.png", "to": .string("\(folder)/planted.png")])),
      ]
      for (tool, input) in refused {
        let response = try await harness.post("/v1/tools/\(tool)", input)
        #expect(response.status != .ok, "\(tool) \(input.jsonString())")
      }
      let put = try await harness.put("/v1/f\(copy)", .string("x"))
      #expect(put.status != .ok)

      #expect(try await harness.space.fs(.shared).read(copy).1 == pixels)
      #expect(try await harness.space.fs(.shared).read("/loose.png").1 == pixels)
    }
  }

  @Test func theBase64JSONUploadIsGone() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let response = try await harness.post(
        "/v1/conversation/message",
        .object([
          "message": "look", "session": .string(id.rawValue),
          "attachments": .array([.object(["name": "shot.png", "data": .string(pixels.base64EncodedString())])]),
        ]),
      )
      #expect(response.status == .badRequest)
    }
  }

  @Test func aFileAtTheSizeLimitIsAcceptedAndOneByteMoreIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let over = try await refusal(harness.streamed(id, sizes: [AttachmentLimits.maxFileBytes + 1]))
      #expect(over == (.contentTooLarge, "attachmentTooLarge"))

      let (post, _) = try await harness.accepted(harness.streamed(id, sizes: [AttachmentLimits.maxFileBytes]))
      let stored = try #require(try await harness.stored(post).first)
      guard case let .file(_, _, size) = stored else {
        Issue.record("stored as \(stored), not a file")
        return
      }
      #expect(size == AttachmentLimits.maxFileBytes)
    }
  }

  @Test func aTotalOverTheLimitIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let sizes = Array(repeating: AttachmentLimits.maxFileBytes, count: 3) + [1]
      let over = try await refusal(harness.streamed(id, sizes: sizes))
      #expect(over == (.contentTooLarge, "attachmentsTooLarge"))
    }
  }

  @Test func moreAttachmentsThanTheCapAreRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      let files = (0 ... AttachmentLimits.maxPerMessage).map { ("shot\($0).png", pixels) }
      #expect(try await refusal(harness.multipart(id, files)) == (.badRequest, "tooManyAttachments"))

      _ = try await harness.space.fs(.shared).write("/shots/one.png", pixels, ifMatch: nil)
      let eight = Array(files.prefix(AttachmentLimits.maxPerMessage))
      #expect(try await refusal(harness.multipart(id, eight, paths: ["/shots/one.png"])) == (.badRequest, "tooManyAttachments"))
    }
  }

  @Test func aSpacePathCountsTowardTheSizeLimitBeforeItIsRead() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      _ = try await harness.space.fs(.shared).write("/big.bin", Data(repeating: 1, count: AttachmentLimits.maxFileBytes + 1), ifMatch: nil)
      #expect(try await refusal(harness.postToBox(id, paths: ["/big.bin"])) == (.contentTooLarge, "attachmentTooLarge"))
    }
  }

  @Test func malformedPostsAreRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      var noMessage = MultipartForm(boundary: boundary)
      noMessage.appendFile(name: "file", filename: "a.txt", contentType: "text/plain", bytes: Data("a".utf8))
      #expect(try await harness.send(noMessage.finish(), contentType: noMessage.contentType).status == .badRequest)

      var stray = MultipartForm(boundary: boundary)
      stray.appendField("message", JSONValue.object(["message": "x", "session": .string(id.rawValue)]).jsonString())
      stray.appendField("image", "base64")
      #expect(try await harness.send(stray.finish(), contentType: stray.contentType).status == .badRequest)

      let truncated = Body.bytes(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a\"\r\n\r\nabc".utf8))
      #expect(try await harness.send(truncated, contentType: "multipart/form-data; boundary=\(boundary)").status == .badRequest)
    }
  }

  @Test func anAttachmentThatIsNotInTheSpaceIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      #expect(try await harness.postToBox(id, paths: ["/shots/gone.png"]).status == .notFound)
    }
  }

  @Test func aPathThatIsNotAnAbsoluteSpacePathIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("seen") }
      let id = try await harness.createSession()
      _ = try await harness.space.fs(.shared).write("/shots/a.png", Data("a".utf8), ifMatch: nil)
      for path in ["machines://m1/shot.png", "shots/a.png"] {
        let response = try await harness.postToBox(id, paths: [path])
        #expect(response.status == .badRequest)
        #expect(try await response.text().contains("must be a space path"))
      }
    }
  }
}
