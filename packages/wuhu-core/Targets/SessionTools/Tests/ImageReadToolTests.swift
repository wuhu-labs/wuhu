import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

private let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF]

// A png signature and an IHDR chunk declaring 6000x4000.
private let pngHeader: [UInt8] = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x17,
  0x70,
  0x00,
  0x00,
  0x0F,
  0xA0,
]

@Suite struct ImageReadToolTests {
  @Test func imageFilesReadAsAttachedImages() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/shots/login.png", Data(pngMagic), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .read(result) = try await world.run("read", .object(["path": "/shots/login.png"])) else {
        throw Mismatch("image read failed")
      }
      let image = try #require(result.image)
      #expect(image.mimeType == "image/png")
      #expect(image.byteCount == pngMagic.count)
      guard case .blob = image.source else {
        Issue.record("an image read must leave a reference in the transcript, not bytes")
        return
      }
      #expect(try await space.imageBytes(image) == Data(pngMagic))
      #expect(result.content.contains("image image/png, \(pngMagic.count) bytes"))
    }
  }

  @Test func imagesRecordTheirPixelSize() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/wide.png", Data(pngHeader), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .read(result) = try await world.run("read", .object(["path": "/wide.png"])) else {
        throw Mismatch("image read failed")
      }
      #expect(result.image?.pixels != nil)
      #expect(result.content.contains("6000x4000 px"))
    }
  }

  @Test func imagesPastTheReadCeilingAreRefused() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var bytes = Data(pngHeader)
      bytes.append(Data(count: (50 << 20) + 1 - bytes.count))
      _ = try await space.fs(.shared).write("/huge.png", bytes, ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let refused = try await world.run("read", .object(["path": "/huge.png"]))
      #expect(try failureMessage(refused).contains("read takes images up to \(50 << 20) bytes"))
    }
  }

  @Test func imagesWhoseBytesDisagreeWithTheirNameAreRefused() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/liar.jpg", Data(pngHeader), ifMatch: nil)
      _ = try await space.fs(.shared).write("/text.png", Data("hello".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let liar = try await world.run("read", .object(["path": "/liar.jpg"]))
      #expect(try failureMessage(liar).contains("is named as image/jpeg but its bytes are image/png"))
      let text = try await world.run("read", .object(["path": "/text.png"]))
      #expect(try failureMessage(text).contains("but its bytes are no image format read takes"))
    }
  }

  @Test func linesOnAnImageIsTyped() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/a.png", Data(pngMagic), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let refused = try await world.run("read", .object(["path": "/a.png", "lines": "1-2"]))
      #expect(try failureMessage(refused).contains("lines applies to text files"))
    }
  }
}
