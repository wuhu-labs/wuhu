# SecretMasking

`SecretMasker` replaces every form of each secret with `***`. A secret's forms are the value itself, the value with surrounding whitespace trimmed, and the JSON string encoding of both without the surrounding quotes (`"`, `\` and control characters escaped as `JSON.stringify` does), also with `/` escaped as `\/` (Foundation, PHP). A secret that is empty or only whitespace has no forms. At any position the longest matching form wins.

`masked(_:)` masks one whole text. `formUnion(_:)` adds another masker's secrets, keeping a stream's held bytes. `mask(_:)` and `flush()` mask a stream: a position where some form could still complete with later bytes is held back, never emitted, so a form split across chunks is masked and the concatenated output equals `masked` of the concatenated input.
