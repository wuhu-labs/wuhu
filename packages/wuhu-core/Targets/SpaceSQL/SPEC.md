# SpaceSQL

## Conversation views

Grouped conversation views expose nullable `title` from the additive `conversation_titles` side table. Unqualified conversations include the acting group's readable conversations and memberships; qualified and wildcard names retain their group scope. `users` channels admit person members and sessions in groups reading the home group. Group access alone does not admit a non-member person. Session membership rows left in historical users channels are omitted from `conversation_members`; channel membership exposes only people. Message and member views use the same channel visibility as conversations. Non-channel conversation visibility remains unchanged.
