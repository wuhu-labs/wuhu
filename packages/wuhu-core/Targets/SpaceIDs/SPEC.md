# Space identifiers

`SpaceIDs` owns `GroupID`, `InvalidGroupHost`, `AccountID`, `SessionID`, `ConversationID`, `MessageID`, `RequestID` and `SubscriptionID`, without dependencies. Raw-value construction and Codable representations are unchanged; construction does not validate a spelling.

`GroupID` parses group hosts and addresses, validates group spellings, and names the shared and settings groups. Its viewing-spelling extension remains in SpaceContract. `AccountID.isValid` accepts the `ac_` prefix followed by eight lowercase ASCII letters or digits. `AccountID(suffix:)` adds that private prefix to a caller-generated suffix; `suffixLength` tells the caller how many random characters to generate. `SessionID.homePath` names the session’s home directory.
