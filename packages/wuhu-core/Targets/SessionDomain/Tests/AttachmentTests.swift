import Foundation
import JSONValue
import SessionDomain
import enum SpaceContract.ImageMedia
import struct SpaceContract.PixelSize
import Testing
import WuhuAI

@Suite struct AttachmentTests {
  private let budget = ContextBudget(maxInput: 100_000, maxOutput: 10000)
  private let attachment = Attachment.image(path: "/sessions/s-1/attachments/a.png", mimeType: "image/png", size: 1024)

  @Test func `an image attachment round-trips through its tagged wire object`() throws {
    let encoded = try JSONEncoder().encode(MessageContent(text: "look", attachments: [attachment]))
    let wire = JSONValue.parse(String(decoding: encoded, as: UTF8.self))
    #expect(wire == JSONValue.parse("""
    {"text":"look","attachments":[\
    {"kind":"image","path":"/sessions/s-1/attachments/a.png","mimeType":"image/png","size":1024}]}
    """))

    let decoded = try JSONDecoder().decode(MessageContent.self, from: encoded)
    #expect(decoded == MessageContent(text: "look", attachments: [attachment]))
  }

  @Test func `a file attachment round-trips with its type and size`() throws {
    let file = Attachment.file(path: "/c/clip.mp4", mimeType: "video/mp4", size: 42)
    let encoded = try JSONEncoder().encode(MessageContent(text: "look", attachments: [file]))
    #expect(JSONValue.parse(String(decoding: encoded, as: UTF8.self)) == JSONValue.parse("""
    {"text":"look","attachments":[{"kind":"file","path":"/c/clip.mp4","mimeType":"video/mp4","size":42}]}
    """))
    #expect(try JSONDecoder().decode(MessageContent.self, from: encoded).attachments == [file])
  }

  @Test func `an image stored before sizes were recorded still decodes`() throws {
    let wire = #"{"text":"look","attachments":[{"kind":"image","path":"/a.png","mimeType":"image/png"}]}"#
    let decoded = try JSONDecoder().decode(MessageContent.self, from: Data(wire.utf8))
    #expect(decoded.attachments == [.image(path: "/a.png", mimeType: "image/png", size: nil)])
    #expect(decoded.modelImages == decoded.attachments)
  }

  @Test func `an image round-trips its pixel size as width and height`() throws {
    let sized = Attachment.image(path: "/a.png", mimeType: "image/png", size: 1024, pixels: PixelSize(width: 6000, height: 4000))
    let encoded = try JSONEncoder().encode(MessageContent(text: "look", attachments: [sized]))
    #expect(JSONValue.parse(String(decoding: encoded, as: UTF8.self)) == JSONValue.parse("""
    {"text":"look","attachments":[\
    {"kind":"image","path":"/a.png","mimeType":"image/png","size":1024,"width":6000,"height":4000}]}
    """))
    #expect(try JSONDecoder().decode(MessageContent.self, from: encoded).attachments == [sized])
  }

  // A server rolled back past this change reads rows written by it.
  @Test func `a row carrying width and height decodes on the reader from before them`() throws {
    let sized = Attachment.image(path: "/a.png", mimeType: "image/png", size: 1024, pixels: PixelSize(width: 6000, height: 4000))
    let encoded = try JSONEncoder().encode([sized])
    #expect(try JSONDecoder().decode([ReaderBeforePixels].self, from: encoded) == [
      .image(path: "/a.png", mimeType: "image/png", size: 1024),
    ])
  }

  @Test func `a file without a size is a decode error`() {
    let wire = #"{"text":"look","attachments":[{"kind":"file","path":"/a.mp4","mimeType":"video/mp4"}]}"#
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(MessageContent.self, from: Data(wire.utf8))
    }
  }

  @Test func `an unknown attachment kind is a decode error`() {
    let wire = #"{"text":"look","attachments":[{"kind":"video","path":"/a.mp4","mimeType":"video/mp4"}]}"#
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(MessageContent.self, from: Data(wire.utf8))
    }
  }

  @Test func `the header parser reads each format's pixel size`() {
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
      + [0, 0, 0x17, 0x70, 0, 0, 0x0F, 0xA0]
    #expect(ImageMedia.pixelSize(ofBytes: png) == PixelSize(width: 6000, height: 4000))

    let gif = Array("GIF89a".utf8) + [0x40, 0x01, 0xF0, 0x00]
    #expect(ImageMedia.pixelSize(ofBytes: gif) == PixelSize(width: 320, height: 240))

    // SOI, an APP0 segment to skip, then a baseline SOF0 frame header.
    let jpeg: [UInt8] = [
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x04,
      0x00,
      0x00,
      0xFF,
      0xC0,
      0x00,
      0x11,
      0x08,
      0x02,
      0x58,
      0x03,
      0x20,
      0x03,
      0x01,
      0x22,
      0x00,
    ]
    #expect(ImageMedia.pixelSize(ofBytes: jpeg) == PixelSize(width: 800, height: 600))

    let riff = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
    let lossy = riff + Array("VP8 ".utf8) + [0, 0, 0, 0] + [0, 0, 0, 0x9D, 0x01, 0x2A] + [0x80, 0x02, 0xE0, 0x01]
    #expect(ImageMedia.pixelSize(ofBytes: lossy) == PixelSize(width: 640, height: 480))
    // VP8L packs width-1 and height-1 into 14 bits each after the 0x2F signature.
    let bits: UInt32 = 639 | (479 << 14)
    let lossless = riff + Array("VP8L".utf8) + [0, 0, 0, 0, 0x2F]
      + [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
      + [0, 0, 0, 0, 0]
    #expect(ImageMedia.pixelSize(ofBytes: lossless) == PixelSize(width: 640, height: 480))
    // VP8X stores width-1 and height-1 as 24-bit little-endian after 4 flag bytes.
    let extended = riff + Array("VP8X".utf8) + [0, 0, 0, 0] + [0, 0, 0, 0] + [0x7F, 0x02, 0x00, 0xDF, 0x01, 0x00]
    #expect(ImageMedia.pixelSize(ofBytes: extended) == PixelSize(width: 640, height: 480))

    #expect(ImageMedia.pixelSize(ofBytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]) == nil, "a signature with no header")
    #expect(ImageMedia.pixelSize(ofBytes: Array("just words".utf8)) == nil)
  }

  @Test func `the sniffer names each format from its signature and nothing else`() {
    #expect(ImageMedia.mimeType(ofBytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]) == "image/png")
    #expect(ImageMedia.mimeType(ofBytes: [0xFF, 0xD8, 0xFF, 0xE0]) == "image/jpeg")
    #expect(ImageMedia.mimeType(ofBytes: Array("GIF89a...".utf8)) == "image/gif")
    #expect(ImageMedia.mimeType(ofBytes: Array("GIF87a...".utf8)) == "image/gif")
    #expect(ImageMedia.mimeType(ofBytes: Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == "image/webp")

    #expect(ImageMedia.mimeType(ofBytes: Array("just words".utf8)) == nil)
    #expect(ImageMedia.mimeType(ofBytes: Array("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)) == nil, "a RIFF container that is not WEBP")
    #expect(ImageMedia.mimeType(ofBytes: [0x89, 0x50]) == nil, "a truncated signature")
    #expect(ImageMedia.mimeType(ofBytes: []) == nil)
  }

  @Test func `a message with an attachment renders text plus a reference to the file`() async {
    let transcript = Transcript(items: [Fix.message(text: "what does this say?", attachments: [attachment])])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")

    let content = context.messages[0].user?.content
    #expect(content?.count == 2)
    guard case let .text(text) = content?.first else {
      Issue.record("the header and body render first")
      return
    }
    #expect(text.text.contains("what does this say?"))
    #expect(text.text.contains("<attachments>\n/sessions/s-1/attachments/a.png (image/png)\n</attachments>"))
    guard case let .media(media) = content?.last else {
      Issue.record("the image follows as a media block")
      return
    }
    #expect(media.mimeType == "image/png")
    #expect(MediaReference(media.url) == .spaceFile("/sessions/s-1/attachments/a.png"))
  }

  @Test func `what the model cannot take as an image arrives as one line with its type and size`() async {
    let clip = Attachment.file(path: "/c/clip.mp4", mimeType: "video/mp4", size: 41_943_040)
    let big = Attachment.image(path: "/c/big.png", mimeType: "image/png", size: ImageMedia.maxBytes + 1)
    let transcript = Transcript(items: [Fix.message(text: "see", attachments: [attachment, clip, big])])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")

    let content = context.messages[0].user?.content ?? []
    guard case let .text(text) = content.first else {
      Issue.record("the header and body render first")
      return
    }
    #expect(text.text.contains("""
    <attachments>
    /sessions/s-1/attachments/a.png (image/png)
    /c/clip.mp4 (video/mp4, 41943040 bytes)
    /c/big.png (image/png, \(ImageMedia.maxBytes + 1) bytes)
    </attachments>
    """))
    let media = content.compactMap { block -> MediaReference? in
      guard case let .media(media) = block else { return nil }
      return MediaReference(media.url)
    }
    #expect(media == [.spaceFile("/sessions/s-1/attachments/a.png")])
  }

  @Test func `a stored file and a stored 50 MiB image each reach the model as their line`() async throws {
    let stored = #"""
    {"text":"see","attachments":[\#
    {"kind":"file","path":"/c/report.pdf","mimeType":"application/pdf","size":598},\#
    {"kind":"image","path":"/c/huge.png","mimeType":"image/png","size":52428800}]}
    """#
    let content = try JSONDecoder().decode(MessageContent.self, from: Data(stored.utf8))
    let transcript = Transcript(items: [Fix.message(text: content.text, attachments: content.attachments)])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")

    let blocks = context.messages[0].user?.content ?? []
    #expect(blocks.count == 1)
    guard case let .text(text) = blocks.first else {
      Issue.record("the header and body render first")
      return
    }
    #expect(text.text.contains("""
    <attachments>
    /c/report.pdf (application/pdf, 598 bytes)
    /c/huge.png (image/png, 52428800 bytes)
    </attachments>
    """))
  }

  @Test func `an attachment costs an image estimate, not its path length`() {
    let plain = Transcript(items: [Fix.message(text: "look")])
    let carrying = Transcript(items: [Fix.message(text: "look", attachments: [attachment])])
    #expect(carrying.estimatedContextTokens(images: .claude) - plain.estimatedContextTokens(images: .claude) > 1500)
  }

  @Test func `every attachment in the transcript renders its own reference`() async {
    let transcript = Transcript(items: [
      Fix.message(text: "a", attachments: [attachment]),
      Fix.direct(),
      Fix.message(conversation: "ch2", text: "b", attachments: [attachment]),
    ])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    let references = context.messages.flatMap { message in
      (message.user?.content ?? []).compactMap { block -> MediaReference? in
        guard case let .media(media) = block else { return nil }
        return MediaReference(media.url)
      }
    }
    #expect(references == [
      .spaceFile("/sessions/s-1/attachments/a.png"),
      .spaceFile("/sessions/s-1/attachments/a.png"),
    ])
  }
}

// Attachment's decoder as it was before pixel sizes were recorded, frozen.
private enum ReaderBeforePixels: Hashable, Decodable {
  case image(path: String, mimeType: String, size: Int?)
  case file(path: String, mimeType: String, size: Int)

  private enum Kind: String, Decodable {
    case image
    case file
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case path
    case mimeType
    case size
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let path = try container.decode(String.self, forKey: .path)
    let mimeType = try container.decode(String.self, forKey: .mimeType)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .image:
      self = .image(path: path, mimeType: mimeType, size: try container.decodeIfPresent(Int.self, forKey: .size))
    case .file:
      self = .file(path: path, mimeType: mimeType, size: try container.decode(Int.self, forKey: .size))
    }
  }
}
