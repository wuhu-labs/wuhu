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

  @Test func `what intake keeps is within what every family takes`() {
    let kept = ImageLimits.intake.fitted(PixelSize(width: 6000, height: 4000))
    #expect(kept.longEdge == 2000)
    for family in [ImageLimits.claude, .openAI] {
      #expect(family.fitted(kept) == kept)
      #expect(ImageLimits.intake.maxBytes <= family.maxBytes)
    }
  }

  @Test func `tokens are counted from the size sent`() {
    #expect(ImageLimits.claude.tokens(PixelSize(width: 280, height: 140)) == 50)
    #expect(ImageLimits.claude.tokens(PixelSize(width: 6000, height: 4000)) <= 4784)
    #expect(ImageLimits.claude.tokens(nil) == 4784)
    #expect(ImageLimits.openAI.tokens(PixelSize(width: 320, height: 320)) == 120)
    #expect(ImageLimits.openAI.tokens(nil) == 36000)
  }
}
