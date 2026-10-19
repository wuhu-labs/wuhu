public func seconds(_ duration: Duration) -> String {
  let (whole, attoseconds) = duration.components
  guard attoseconds != 0 else { return "\(whole)" }
  return "\(Double(whole) + Double(attoseconds) / 1e18)"
}
