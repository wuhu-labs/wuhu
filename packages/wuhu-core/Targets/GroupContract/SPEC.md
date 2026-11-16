# GroupContract

`CellContext.settings()` returns the settings cell's read handle through the provided `GroupCells` factory. `SettingsReading.isSpaceAdmin(account:)` answers whether that `SpaceIDs.AccountID` holds an admin role there. Only the Group implementation names the settings group; no SQL, database, rows or cell types cross the contract. An unprovided factory traps.
