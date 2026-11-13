import StructuredQueries

extension SpaceCell {
  public func persona(_ name: String, belongsTo account: AccountID) -> Bool {
    !db.rows(PersonaRow.where { $0.name.eq(name) && $0.accountID.eq(account.rawValue) }).isEmpty
  }
}
