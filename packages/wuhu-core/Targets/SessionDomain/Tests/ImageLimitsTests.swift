import SessionDomain
import struct SpaceContract.PixelSize
import Testing

@Suite struct ImageLimitsTests {
  private func patches(_ size: PixelSize, _ patch: Int) -> Int {
    ((size.width + patch - 1) / patch) * ((size.height + patch - 1) / patch)
  }

  @Test func `an image within the limits keeps its size`() {
    let size = PixelSize(width: 1200, height: 800)
    #expect(ImageLimits.claude.fitted(size) == size)
    #expect(ImageLimits.openAI.fitted(size) == size)
  }

  @Test func `Claude fits the long edge and the patch budget`() {
    let fit = ImageLimits.claude.fitted(PixelSize(width: 6000, height: 4000))
    #expect(fit.longEdge <= 2576)
    #expect(patches(fit, 28) <= 4784)
    #expect(fit.longEdge > 2000, "no more shrinking than the budget needs")
    let ratio = Double(fit.width) / Double(fit.height)
    #expect(abs(ratio - 1.5) < 0.01, "the aspect ratio holds")
  }

  @Test func `OpenAI keeps any size up to its patch budget`() {
    let tall = PixelSize(width: 1000, height: 20000)
    #expect(ImageLimits.openAI.fitted(tall) == tall, "630 patches of 32 px")
    let fit = ImageLimits.openAI.fitted(PixelSize(width: 10000, height: 10000))
    #expect(patches(fit, 32) <= 30000)
    #expect(patches(fit, 32) > 28000)
  }

  @Test func `more than twenty images in one Claude request are fitted to 2000 px`() {
    let size = PixelSize(width: 2400, height: 1200)
    #expect(ImageLimits.claude.forRequest(imageCount: 20).fitted(size) == size)
    #expect(ImageLimits.claude.forRequest(imageCount: 21).fitted(size).longEdge == 2000)
    #expect(ImageLimits.openAI.forRequest(imageCount: 50).maxLongEdge == ImageLimits.openAI.maxLongEdge)
  }

  @Test func `the images of one request share its byte budget`() {
    #expect(ImageLimits.openAI.forRequest(imageCount: 1).maxBytes == 20 << 20)
    #expect(ImageLimits.openAI.forRequest(imageCount: 10).maxBytes == (30 << 20) / 16)
    #expect(ImageLimits.claude.forRequest(imageCount: 1).maxBytes == 3 << 20)
    #expect(ImageLimits.claude.forRequest(imageCount: 12).maxBytes == (18 << 20) / 16)
    for limits in [ImageLimits.claude, .openAI] {
      let budget = limits.requestBytes ?? 0
      // Base64 grows the bytes by a third; the rest of the request is text.
      #expect(budget * 4 / 3 < (limits == .claude ? 32_000_000 : 50_000_000) - 6_000_000)
      #expect(limits.forRequest(imageCount: 40).maxBytes * 40 <= budget)
    }
  }

  @Test func `the share steps only at powers of two, so images already sent keep their bytes`() {
    let budget = 30 << 20
    let expected: [(Int, Int)] = [(1, 1), (2, 2), (3, 4), (4, 4), (5, 8), (8, 8), (9, 16), (15, 16), (16, 16), (17, 32), (33, 64)]
    for (count, shares) in expected {
      #expect(ImageLimits.openAI.forRequest(imageCount: count).maxBytes == min(20 << 20, budget / shares), "\(count) images")
    }
    let steps = Set((1 ... 64).map { ImageLimits.openAI.forRequest(imageCount: $0).maxBytes })
    #expect(steps.count == 7, "one share for 1, 2, 3-4, 5-8, 9-16, 17-32, 33-64")
  }

  @Test func `tokens are counted from the size sent`() {
    #expect(ImageLimits.claude.tokens(PixelSize(width: 280, height: 140)) == 50)
    #expect(ImageLimits.claude.tokens(PixelSize(width: 6000, height: 4000)) <= 4784)
    #expect(ImageLimits.claude.tokens(nil) == 4784)
    #expect(ImageLimits.openAI.tokens(PixelSize(width: 320, height: 320)) == 120)
    #expect(ImageLimits.openAI.tokens(nil) == 36000)
  }
}
