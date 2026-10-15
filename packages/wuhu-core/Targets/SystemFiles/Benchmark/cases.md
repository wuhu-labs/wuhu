# Skill benchmark cases: intended behaviour

Subject: `deepseek/deepseek-flash`, a kernel **agent** session created from the condition's template, on a throwaway server. A person posts the prompt into its box; the graded reply is its last message of the turn. Each subject gets its own copy of the fixtures, `{fx}` = `/bench/<case>-<n>/fixtures`, and its own user folder, `{sb}` = `/bench/<case>-<n>/work`. `{machine}` is the run's machine, `box`. Prompts are typed the way a normal user would. Each case lists what must be observable afterwards; `cases.json` holds the exact prompts, the deterministic checks and the judge rubric.

## 1. capabilities

_Prompt:_ "I keep my reading list in {fx}/reading/books.md and it's getting unwieldy. I want to see what I'm currently reading at a glance on my phone (ideally without even opening anything), and be able to update it from my phone or just by telling you. What can you set up here for this? Go ahead and build it…"

_Afterwards:_ a `.table` in the user folder holding the 10 books (title, author, status, rating…); a phone surface on top of it — a widget JSON (Home/Lock Screen, "without opening anything"), a `.view` board or an HTML page; the reply names the surface, says how to add it on the phone and how updates happen (tell the agent → it mutates rows). No invented features.

## 2. style

_Prompt:_ "I keep getting write conflicts ('stale read' / 'read it first') when I edit files here with you. What's going on and how do I avoid it?"

_Afterwards:_ only a reply. It opens with the one-sentence answer (writes are guarded by the revision last read; something changed in between), then why, then the 2–3 things to do; each layer shorter than the last; ≤ ~1800 chars, no preamble, no restating the question, no closing offer.

## 3. long-doc

_Prompt:_ "Write an onboarding guide for someone joining the Sundial project next week — everything is under {fx}/sundial. Cover what it is, how it's put together, the decisions we made and why, who to ask, and the vocabulary. Be thorough… My folder for this is {sb}."

_Afterwards:_ `{sb}/<something>.md`, a complete guide (components, data flow, D1–D6 with reasons, owners, glossary) built from the fixtures; the reply is a short pointer with the path and a few lines on what's inside, not the guide pasted in chat.

## 4. temp-files

_Prompt:_ "Merge the three CSV exports in {fx}/exports into one file at {sb}/all-orders.csv — dedupe by order_id, sort by date. Keep a working log of what you did as you go…, and tell me how many rows came from each file and how many duplicates you dropped."

_Afterwards:_ `{sb}/all-orders.csv` with 13 unique orders sorted by date (6 + 5 + 6 rows in, 4 duplicates dropped); the working log and any scratch under `/_/sessions/<id>/`, linked from the reply; nothing else in the user folder, nothing anywhere else in the space.

## 5. html-page (regression)

_Prompt:_ "Make me a page I can open on my iPhone showing my expenses from {fx}/expenses.table: total per category, biggest first, and it should update live when I add rows. Save it as {sb}/expenses.html."

_Afterwards:_ the page imports `wuhu:space`, uses `observe` with a GROUP BY category ORDER BY total DESC; carries the mobile defaults (viewport meta with `maximum-scale=1, viewport-fit=cover`, `touch-action: manipulation`, `overflow-x: clip; overscroll-behavior-x: none`); pads by `--wuhu-inset-*` or links `/theme.css`; no `/_/query`, no `/v1/`.

## 6. data-org

_Prompt:_ "My job hunt notes in {fx}/jobs are a mess. I want to see at a glance where each application stands, what's due, and not lose contacts. How would you organize this in Wuhu? Propose first, don't change anything yet."

_Afterwards:_ fixtures unchanged, nothing created. The reply proposes a table with named columns and/or one doc per application with YAML frontmatter, says which it recommends and why, proposes a board/widget/page on top, is grounded in the five companies and the two dates in the notes, and ends by asking for a go-ahead. Short enough to approve in a minute.

## 7. avatar

Needs an image provider; the throwaway server has none, so the runner skips it (`requires: ["image"]`).

_Prompt 1:_ "Give yourself a profile picture — a small owl with reading glasses, something friendly."
_Prompt 2:_ "3, but the owl is too small in the circle — zoom in on it a bit."

_Afterwards:_ turn 1: 4 PNG candidates under `/_/sessions/<id>/…`, reply = numbered links + "which one?". Turn 2: candidate 3 cropped/zoomed (on a machine with PIL/ImageMagick, or edited) and promoted to `/_/sessions/<id>/avatar.png`; the bytes differ from every candidate; reply is one or two lines. Regenerating a new owl instead of cropping the chosen one is a fail.

## 8. file-move

_Prompt:_ "There's a photo at {fx}/photo.png. I need a 256×256 centre-cropped thumbnail of it saved as {sb}/photo-thumb.png. {machine} has python with PIL if you need it."

_Afterwards:_ `{sb}/photo-thumb.png` is a 256×256 PNG. The route is recorded (run_script `readBytes`/`writeBytes` + `wuhu:machine` read/write, or `wuhu cat`/`wuhu put` in an exec), and whether it detoured (guessed URLs, asked, gave up on binary).

## 9. handlers

_Prompt:_ "Whenever someone adds a row with priority 'urgent' to {sb}/inbox.table, append a line '<time> <title>' to {sb}/alerts.md. This has to keep working on its own after you're done with this chat." (The table exists with two non-urgent rows.)

_Afterwards:_ an `observe` subscription owned by the session with a **handler module** (a space script file); when the harness inserts an urgent row, `{sb}/alerts.md` gets the line within 90 s with no new inference; the reply says where the handler lives and how to stop it. A handler-less observe that relies on waking the session is a partial.

## 10. model-group

_Prompt:_ "Create an idle child task titled bench-{tag}-group-child using the named model group bench-deepseek. Request that group as its target, not the concrete DeepSeek provider/model behind it. Don’t send it a message or start any work yet; tell me the child’s session id."

_Afterwards:_ exactly one child with that title is a task under the subject, its additive route intent has group_id bench-deepseek, and it has no work. The deterministic check reads actual child rows and route intent; prose claims or selecting the same concrete DeepSeek member do not count. The sessions skill should have been read. The fixture group is a strict one-member select declaration in /model-groups.json; setup only writes it. Smoke on pinned dev.114 checks seeding/template/message transport without executing grouped creation; a scored run needs a group-capable release.

## 11. context-dedupe

Two machine-side fixture checkouts carry byte-identical AGENTS.md files with a reply instruction, plus different README.md facts. The prompt asks the subject to read the first README then the second, without explicitly reading AGENTS.md or compacting. It does not reveal the required `CHECKOUT-NOTE:` prefix.

_Afterwards:_ deterministic checks require ordered machine `read` calls, the second AGENTS.md's generation-neutral identical-text pointer, and a final reply retaining the prefix and both facts. The judge checks that the one-sentence answer still follows the original instruction after the pointer arrives. A server predating dedupe fails the pointer check rather than silently giving the benchmark an easier full-text repeat. Smoke seeds both machine checkouts and verifies their identical instructions are readable without inference; keyed runs belong to Backend's release benchmark.

## 12. cache-warming

_Text-only smoke input:_ an idle/no-other-work scenario and the exact warming notice wording, including the natural-boundary compaction offer. For this smoke only, the agent is explicitly asked to post its compact-or-decline choice in one sentence.

_Afterwards:_ a short decision recognizing that compaction is optional, with no new/changed files and no invented task. This lightweight case checks understanding of the advisory offer, not scheduling or production silence; it does not inject a system notice, require a newer binary, or modify the driver. A real system-notice/no-visible-output case needs the benchmark lead's harness support separately.

## 13. machine-v2-parity

_Text-only smoke:_ show normal grep tool arguments for `machines://box-v2/tmp/project`, regex `^item[0-9]+$`, and explain opaque step continuation in traversal order. Explain typed missing-kind and credential-expiry failures without a transport or identity fallback.

_Afterwards:_ deterministic checks require the normal tool path/regex, step continuation, explicit expiry and no files changed. The judge rejects the removed dedicated v2 script API, renewal and anonymous/wallet/v1 fallback.

## Scoring

A run passes when every `required` deterministic check passes **and** the judge says PASS against the rubric. Pass rate per case is over 3 runs per condition. The judge is `codex/gpt-6.1-sol`; it sees the prompt, the reply, the deterministic results, the files the session created (with contents, truncated) and token/turn counts — not the tool trace, so "route" notes are inferred from the reply and the files.

## 13. model-route-handoff

_Text-only smoke:_ a last-resort quota route notice with an outstanding request. The agent explains its next action in one sentence without writing files. The judge requires continuing the outstanding request, re-reading material when needed, and respecting already committed tool receipts; a route change does not complete a request or permit replaying the former account's signatures.
