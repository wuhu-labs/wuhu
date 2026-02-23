# macOS App Mockup

## What This Is

Build a static mockup of the new Wuhu macOS app. All data is hardcoded —
no server connection, no API calls, no WuhuClient. Pure SwiftUI with TCA,
dummy data structs, and the full navigation structure. This is a design
prototype to validate the layout and feel before wiring up real data.

## Design Language

- **Tint color: orange.** Accents, selection highlights, active indicators,
  buttons — all orange. Warm, modern, not corporate.
- **Native macOS UI.** Use system components: NavigationSplitView, List,
  Table, toolbar items, SF Symbols. No custom chrome. Let it feel like a
  first-party Apple app.
- **Clean and spacious.** Generous padding, clear hierarchy, no clutter.
  Think Notes.app or Mail.app density, not Electron.
- **Dark mode support.** Test in both. Orange works well in dark mode.

## Navigation Structure

Three-column NavigationSplitView:

### Left Column (Sidebar)

Fixed navigation items with SF Symbols and counts:
- **Home** (house) — activity overview
- **Channels** (bubble.left.and.bubble.right) — channel list
- **Sessions** (terminal) — coding session list
- **Issues** (checklist) — issues from workspace
- **Docs** (doc.text) — workspace documents

Workspace name at the very top of the sidebar.

### Middle Column (List)

Changes based on sidebar selection:

**Sessions:** List sorted by recent activity. Each row shows: title (bold),
environment name (secondary), status indicator (green dot = running,
gray = idle, red = stopped), relative timestamp. Group by: Active, Today,
This Week, Older. Search bar at top.

**Channels:** List of channels. Each row shows: channel name, last message
preview (truncated), timestamp, unread indicator.

**Issues:** List of issue cards. Each shows: title, status badge (open,
in-progress, done — color coded), assignee, priority. Toggle between
list view and kanban view (toolbar button).

**Docs:** File list with frontmatter attribute badges.

### Right Column (Detail)

**Session detail:** Message list with clear visual hierarchy:
- User messages: right-aligned or full-width with distinct background.
- Assistant text: full-width, standard text rendering. Always fully visible.
- Tool calls: collapsible. Show a single summary line (tool name + first
  argument) with a disclosure triangle to expand. When collapsed, tool calls
  should take minimal vertical space.
- Tool results: inside the collapsed tool call section.
- Status bar at top: session title (click to edit), environment, model,
  status indicator.
- Text input at bottom: multi-line, cmd+enter to send. Should feel good.

**Channel detail:** Chat interface.
- Messages in a scrolling list. Each message has: avatar/initial, author
  name, timestamp, content.
- Visual distinction between human messages (standard) and agent messages
  (subtle orange left border or similar).
- `session://` links render as tappable chips that would navigate to the
  session.
- Input at bottom, same quality as session input.

**Issues kanban:** Three columns (Open, In Progress, Done). Cards show
title, assignee badge, priority indicator. Clicking a card would show the
full issue doc.

**Doc detail:** Rendered markdown with frontmatter attributes as badges at
top.

**Home:** For the mockup, show a simple activity feed. Recent events like
"Session 'Fix auth flow' completed", "New issue created: Login bug",
"Channel message from Alice in #general". Each links to the relevant item.

## Dummy Data

Create a `MockData.swift` with static data. Include enough variety to make
the UI feel real:

- 3 channels: #general, #backend, #deployments
- 8-10 sessions across different statuses and environments
- Session messages: include a realistic coding session with user prompt,
  assistant text, tool calls (bash, read_file), tool results, and a final
  summary. At least one session should show a fork origin.
- 5-6 issues: mix of open, in-progress, done
- 3-4 workspace docs
- 2 environments: "wuhu-swift" (local), "sandbox" (folder-template)

## Project Setup

This is a new app in `WuhuMVPApp/`, separate from the existing `WuhuApp/`.
Create a new `project.yml` for XcodeGen. Reference `WuhuApp/project.yml`
for the general structure (packages, signing, etc).

Key points:
- macOS only target. No iOS target for now.
- Import the `Wuhu` package (`path: ..`) for transport types — use
  `WuhuAPI` for any shared model types (sessions, entries, environments,
  etc.) where they fit the mockup. Don't import `WuhuClient` or
  `WuhuCore` — this is a static mockup with no server connection.
- TCA (`ComposableArchitecture`) as the architecture.
- After creating `project.yml`, run `cd WuhuMVPApp && xcodegen generate`
  to produce the Xcode project.

## Architecture Notes

- Keep TCA. Feature per screen: `SidebarFeature`, `SessionListFeature`,
  `SessionDetailFeature`, `ChannelListFeature`, `ChannelDetailFeature`,
  `IssuesFeature`, `DocsFeature`, `HomeFeature`.
- The root `AppFeature` manages the NavigationSplitView columns.
- All data comes from MockData — no dependencies, no effects, no async.
  Pure reducers with static state.
- Don't reference or reuse any code from `WuhuApp/`. Clean slate.

## What "Done" Looks Like

- Open the app, see the three-panel layout.
- Click through sidebar items, see the lists populate.
- Click a session, see a realistic message thread with collapsed tool calls.
- Click a channel, see a chat interface with messages.
- Click Issues, see a kanban board.
- Click a doc, see rendered markdown.
- Everything is orange-tinted and feels like a native Mac app.
- Builds and runs on macOS via `xcodegen generate && open WuhuMVPApp.xcodeproj`.
