// Foundation bridges .posixPermissions to NSNumber but FoundationEssentials
// stores it as UInt; a bare `as? Int` fails closed under the latter.
func posixMode(_ value: Any?) -> Int? {
  (value as? Int) ?? (value as? UInt).map { Int($0) }
}
