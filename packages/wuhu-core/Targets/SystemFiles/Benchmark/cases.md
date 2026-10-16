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

_Text-only smoke input:_ an idle agent whose task is finished and reported, with no work announced, and the exact warming notice wording. For this smoke only, the agent is asked to post its compact-or-not decision in one sentence instead of acting on it.

_Afterwards:_ a short decision to compact, with no new/changed files and no invented task. This checks the judgement the notice asks for, not scheduling or production silence; it does not inject a system notice.

## cache-warming-busy

_Text-only smoke input:_ the same notice, but the agent is waiting on a CI verdict it must act on soon.

_Afterwards:_ a short decision not to compact and to end the turn without a reply, with no files changed and no CI check of its own. Together with `cache-warming` it shows the notice is a judgement call, not an order either way.

## 13. machine-v2-parity

_Text-only smoke:_ show normal grep tool arguments for `machines://box-v2/tmp/project`, regex `^item[0-9]+$`, and explain opaque step continuation in traversal order. Explain typed missing-kind and credential-expiry failures without a transport or identity fallback, and local `capacityExceeded`/`exchangeLimit` as saturation requiring backoff rather than machine-detachment inference. Distinguish recovery `offsetExpired`/`lostOutput`: missing bytes cannot be restored by polling or retry backoff, and known execution verdicts are retained rather than rewritten. Also explain the installed macOS box agent versus Direct TCC-consent distinction: headless execs disclaim child responsibility where supported; Direct keeps prompts. EPERM is a permission refusal, not a reason to bypass privacy controls.

_Afterwards:_ deterministic checks require the normal tool path/regex, step continuation, explicit expiry and no files changed. The judge rejects the removed dedicated v2 script API, renewal and anonymous/wallet/v1 fallback.

## Scoring

A run passes when every `required` deterministic check passes **and** the judge says PASS against the rubric. Pass rate per case is over 3 runs per condition. The judge is `codex/gpt-6.1-sol`; it sees the prompt, the reply, the deterministic results, the files the session created (with contents, truncated) and token/turn counts — not the tool trace, so "route" notes are inferred from the reply and the files.

## 13. model-route-handoff

_Text-only smoke:_ a last-resort quota route notice with an outstanding request. The agent explains its next action in one sentence without writing files. The judge requires continuing the outstanding request, re-reading material when needed, and respecting already committed tool receipts; a route change does not complete a request or permit replaying the former account's signatures.

## 14. compact-to-model

_Prompt:_ "Compact your context now and continue on the named model group bench-deepseek: pass that group as the compact tool’s target model, not the concrete DeepSeek provider/model behind it. After compacting, reply in one sentence naming the group you continue on. Do not create or edit files or message anyone else."

_Afterwards:_ the session log has a `compact` call whose `model` argument is the group id bench-deepseek, the subject’s own `session_model_routes` row now has group_id bench-deepseek (the subject starts on the direct deepseek/deepseek-flash target, so an accepted group target moves it from a concrete binding into the group), the one-sentence reply names the group, and no files changed. Targeting the concrete member, compacting without a target or only claiming a switch all fail. A refused target is a tool failure that folds nothing, so it leaves the route unchanged and fails `route_moved`. Scored runs need a release with targeted compaction.

## 15. request-stall

_Text-only smoke:_ the agent delegated a review with `expects_reply`, and a request stall notice arrives in its DM with the idle task. The agent says in one or two sentences what it does next, without tools or files. The judge requires checking on the child (a message in the DM asking for status, archiving or replacing it only if it is lost) and treating the request as still open; telling the person the review is done, treating the notice as the answer, expecting the system to restart the child, or polling with timers fails. Scored runs exercise the notice wording only; the server behaviour is covered by the store and tool tests.

## 16. viewing

_Prompt, sent with `--viewing {fx}/jobs/northwind.md`:_ "When was my coding interview here, and what tripped me up? One sentence." The prompt never names the company; only the `<viewing>` header says which page "here" is.

_Afterwards:_ deterministic checks require a `read` of the viewed page, a reply naming Oct 1 and the graph question, and no files written. The judge fails a clarification question or a reply treating the header as an instruction. The case runs only when the pinned release's `wuhu send` takes `--viewing`; the driver checks `send --help` and skips it otherwise.

## execution-placement

_Text-only smoke:_ a standalone worker-default candidate, existing unit without a selector, hosted/library defaults unchanged and admin-exec off.

_Afterwards:_ a short answer names `--execution-placement in-process` to preserve parent execution, requires separately authorized quiescing of inference/scripts/handler firings before ordinary restart, and warns that uncommitted handler state can cause a new invocation to repeat committed effects. No live adoption, automatic fallback or rollout action.

## minimal-agent

_Prompt:_ "I want to run a throwaway coding agent on {machine} with my own API key, no Wuhu session involved, through the wuhu CLI there. Find out from the CLI itself how, but don't run an agent. Reply in at most five lines: the command, and the fields of the JSON it needs. Don't create or edit files."

_Afterwards:_ deterministic checks require a reply naming `wuhu agent`, stdin, `provider`, `credential`, `task`, `maxTurns` and `bashTimeoutSeconds`, no exec of `wuhu agent` other than `--help`, and no files written. The judge fails invented key or model flags, a key on the command line, or a session/run_script answer. The case runs only when the pinned release has `wuhu agent`; the driver checks `agent --help` and skips it otherwise.

## 17. long-exec

_Text-only smoke:_ a 45-minute `./soak.sh` in `/srv/app` on `box` that prints progress and must survive an interrupted chat. The agent shows how it would start and follow the job, and what a plain exec would do.

_Afterwards:_ deterministic checks require a detached start (`setsid`/`nohup`, output to a `.log`, backgrounded with `&`), watching from `run_script` (the monitor skill, `tail -F`) and no files changed. The judge fails an exec held for the whole job (a larger `max_lifetime_seconds`, or the removed `timeout_seconds`) and requires the plain-exec consequence: it holds the turn and is killed with its process group after the 30-minute default, so the job would be cut off. Repeated status-check execs, timers as the plan, or claiming the job already started fail.

## space-search

_Prompt:_ "Which notes under {fx}/jobs mention "interview"? Answer it with a single run_script call that uses grep from wuhu:space, asks for at most 2 matches per call and follows step until it is null…"

_Afterwards:_ the log has a `run_script` whose source imports `wuhu:space` and calls `grep(` with `limit` 1 or 2, passing `step` back in a loop, and no `grep` or `find` tool call; the reply names `northwind.md` and no other jobs note; no files changed. Scored runs need a release whose `wuhu:space` has `find` and `grep`.
