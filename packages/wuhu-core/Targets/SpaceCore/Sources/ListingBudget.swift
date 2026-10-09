struct ListingBudget {
  let limit: Int?
  private var used = 0

  init(limit: Int?) { self.limit = limit }

  mutating func consume(_ name: String) throws {
    guard let limit else { return }
    var size = 256
    for byte in name.utf8 {
      let bytes = switch byte {
      case 34, 92: 2
      case 0 ..< 32: 6
      default: 1
      }
      size += bytes
      if size > limit - used { throw SpaceError.listingResultTooLarge(byteLimit: limit) }
    }
    guard size <= limit - used else { throw SpaceError.listingResultTooLarge(byteLimit: limit) }
    used += size
  }
}
