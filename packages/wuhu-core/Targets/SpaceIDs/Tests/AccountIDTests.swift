import struct SpaceIDs.AccountID
import Testing

@Suite struct AccountIDTests {
  @Test func callerGeneratedSuffixFormsAnAccountID() {
    let suffix = String(repeating: "a", count: AccountID.suffixLength)
    let id = AccountID(suffix: suffix)
    #expect(id == AccountID(rawValue: "ac_aaaaaaaa"))
    #expect(AccountID.isValid(id.rawValue))
  }

  @Test func validationPreservesTheAccountSpelling() {
    #expect(AccountID.isValid("ac_abc12345"))
    for spelling in ["abc12345", "ac_abc1234", "ac_abc123456", "ac_Abc12345", "ac_abc1234_", "ac_abc1234é"] {
      #expect(!AccountID.isValid(spelling))
    }
  }
}
