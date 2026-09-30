# CLIKit

## Session archive

`wuhu session archive <id> [--force]` posts `force` to the session archive HTTP route. Force defaults to false; other session action verbs do not accept `--force`. A busy refusal is a nonzero exit and prints the server's complete id/title list.

Archiving a session takes its entire parent-chain subtree, leaves first and root last. A separately created top-level agent has no parent and is not included. Only the root's archive rights are checked. Without force, every session is checked for the existing unfinished-work condition; refusal archives nothing and names every busy session by id and title. With force, busy sessions are interrupted before any archive write, and every open request in the subtree, including an undrained request, is closed with a final-kind message saying the session was archived before reporting. Its requester receives that message even outside the subtree. Unarchive remains single-session, subject to the archive grace window.
